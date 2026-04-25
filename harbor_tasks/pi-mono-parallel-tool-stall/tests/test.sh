#!/bin/bash
set +e

# ============================================================
# Verifier for pi-mono parallel tool stall investigation task.
#
# Core principle: a no-op patch MUST score 0.0.
#
# The instruction says "investigation memo only, do not implement".
# But we want behavioral grounding so a memo alone (which exists on base
# as instruction.md? no — instruction.md is excluded) cannot accidentally
# score on no-op. So we make:
#   - All "memo" gates F2P: they score artifacts that DID NOT exist on
#     the base (new files / agent-produced text). On a no-op patch, no
#     such artifacts exist → 0.
#   - All "behavioral" gates F2P: they require either a code fix in
#     interactive-mode.ts / runner.ts OR a new regression test that
#     exercises serialization. On a no-op patch, neither exists → 0.
# ============================================================

REWARD=0
mkdir -p /logs/verifier

REPO=/workspace/pi-mono
if [ ! -d "$REPO" ]; then
  for cand in /workspace/repo /workspace/pi-mono-* ; do
    [ -d "$cand" ] && REPO="$cand" && break
  done
fi

git config --global --add safe.directory "$REPO" 2>/dev/null || true

export PATH="/usr/local/cargo/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
for p in /root/.bun/bin /usr/local/share/npm/bin /opt/homebrew/bin ; do
  [ -d "$p" ] && export PATH="$p:$PATH"
done

add_reward() {
  REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN{ s=a+b; if (s>1) s=1; if (s<0) s=0; printf "%.4f", s }')
}

finish() {
  awk -v v="$REWARD" 'BEGIN{ if (v<0) v=0; if (v>1) v=1; printf "%.4f\n", v }' > /logs/verifier/reward.txt
  cat /logs/verifier/reward.txt
  exit 0
}

echo "=== Repo: $REPO ==="

INTERACTIVE_TS="$REPO/packages/coding-agent/src/modes/interactive/interactive-mode.ts"
RUNNER_TS="$REPO/packages/coding-agent/src/core/extensions/runner.ts"
AGENT_LOOP_TS="$REPO/packages/agent/src/agent-loop.ts"

if [ ! -f "$INTERACTIVE_TS" ] || [ ! -f "$RUNNER_TS" ] || [ ! -f "$AGENT_LOOP_TS" ]; then
  echo "Required source files missing — repo not at expected path."
  finish
fi

# ============================================================
# REGRESSION GUARD (P2P, gating only — no reward weight)
# Make sure source files still parse (basic sanity: balanced braces and
# no obvious truncation). If the agent broke the source files badly,
# zero out.
# ============================================================
echo ""
echo "=== Regression guard ==="
for f in "$INTERACTIVE_TS" "$RUNNER_TS" "$AGENT_LOOP_TS"; do
  SIZE=$(wc -c < "$f" 2>/dev/null || echo 0)
  if [ "$SIZE" -lt 500 ]; then
    echo "REGRESSION: $f truncated ($SIZE bytes)"
    REWARD=0
    finish
  fi
done

# ============================================================
# Detect: did the agent modify the buggy code? (vs no-op)
# ============================================================
DIFF_LINES=0
if [ -d "$REPO/.git" ]; then
  DIFF_LINES=$(cd "$REPO" && git diff HEAD -- \
    "packages/coding-agent/src/modes/interactive/interactive-mode.ts" \
    "packages/coding-agent/src/core/extensions/runner.ts" \
    "packages/agent/src/agent-loop.ts" \
    2>/dev/null | wc -l)
fi
echo "Code diff lines (in buggy hotspots): $DIFF_LINES"

NEW_FILES=""
if [ -d "$REPO/.git" ]; then
  NEW_FILES=$(cd "$REPO" && git status --porcelain 2>/dev/null | grep -E '^\?\?' | awk '{print $2}')
fi

# ============================================================
# Locate agent-produced memo text (NEW artifacts only — not pre-existing files)
# ============================================================
echo ""
echo "=== Locating agent-produced memo ==="

: > /tmp/memo_content.txt

# Untracked .md/.txt files in the repo (new artifacts the agent created)
if [ -d "$REPO/.git" ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in
      *.md|*.txt|*.MD) ;;
      *) continue ;;
    esac
    case "$f" in
      *node_modules/*|*.git/*|*dist/*|*/README.md|*CHANGELOG*) continue ;;
    esac
    full="$REPO/$f"
    [ -f "$full" ] || continue
    SIZE=$(wc -c < "$full" 2>/dev/null || echo 0)
    [ "$SIZE" -lt 300 ] && continue
    echo "Memo candidate (new): $f ($SIZE bytes)"
    cat "$full" >> /tmp/memo_content.txt
    echo "" >> /tmp/memo_content.txt
  done < <(cd "$REPO" && git status --porcelain 2>/dev/null | grep -E '^\?\?' | awk '{print $2}')
fi

# Agent session jsonl transcripts (new since session start)
for sf in $(find /home /root /workspace -path '*/.claude/projects/*' -name '*.jsonl' 2>/dev/null); do
  EXTRACTED=$(node -e "
    const fs=require('fs');
    try {
      const lines=fs.readFileSync(process.argv[1],'utf8').split('\n').filter(Boolean);
      let buf='';
      for(const line of lines){
        try{
          const d=JSON.parse(line);
          if(d.type==='assistant' && d.message && Array.isArray(d.message.content)){
            for(const c of d.message.content){
              if(c.type==='text' && c.text) buf += c.text + '\n\n';
            }
          }
        }catch(e){}
      }
      process.stdout.write(buf);
    } catch(e){}
  " "$sf" 2>/dev/null)
  if [ -n "$EXTRACTED" ]; then
    printf '%s\n' "$EXTRACTED" >> /tmp/memo_content.txt
  fi
done

# Diff added lines (the agent's actual additions, including new test files / fixes)
if [ -d "$REPO/.git" ]; then
  (cd "$REPO" && git diff HEAD 2>/dev/null) | grep "^+" | grep -v "^+++" | sed 's/^+//' >> /tmp/memo_content.txt
  for nf in $NEW_FILES; do
    full="$REPO/$nf"
    [ -f "$full" ] && cat "$full" >> /tmp/memo_content.txt
  done
fi

MEMO_LEN=$(wc -c < /tmp/memo_content.txt 2>/dev/null || echo 0)
echo "Aggregated agent-produced text: $MEMO_LEN bytes"

# CRITICAL: on a no-op patch, MEMO_LEN should be ~0 (no untracked .md, no diff,
# no new files). The session jsonl may not exist in the verifier sandbox.

# ============================================================
# F2P Gate 1 (weight 0.10): Agent produced substantive memo content
# Only awarded if there's >=2KB of agent-produced text (memo or diff).
# No-op: 0 bytes → 0.
# ============================================================
echo ""
echo "=== F2P Gate 1: Agent-produced memo substance (max 0.10) ==="
G1=$(awk -v n="$MEMO_LEN" 'BEGIN{
  if (n>=10000) print 0.10;
  else if (n>=5000) print 0.07;
  else if (n>=2500) print 0.04;
  else if (n>=1000) print 0.02;
  else print 0;
}')
echo "Gate1: $G1"
add_reward "$G1"

# ============================================================
# F2P Gate 2 (weight 0.10): Memo concept coverage
# Requires memo content to mention root-cause concepts. On no-op
# (no memo) → 0.
# ============================================================
echo ""
echo "=== F2P Gate 2: Concept coverage (max 0.10) ==="
G2=$(node -e "
const fs=require('fs');
let t='';try{t=fs.readFileSync('/tmp/memo_content.txt','utf8').toLowerCase();}catch(e){}
if(t.length<800){console.log(0);process.exit(0);}
const groups=[
  [/parallel/, /promise\.all/, /executetoolcallsparallel/],
  [/sequential|serial(ize|ised|ized)?|queue|mutex/],
  [/interactive|dialog|extensionselector|extensioninput|extensioneditor|ctx\.ui/],
  [/stall|hang|deadlock|orphan|race|block/],
  [/single[- ]slot|overwrit|clobber|editorcontainer\.clear|replace|evict/],
  [/oracle/],
  [/recommendation|option/],
];
let hits=0;
for(const g of groups){ for(const r of g){ if(r.test(t)){ hits++; break; } } }
let s=0;
if(hits>=7) s=0.10;
else if(hits>=6) s=0.08;
else if(hits>=5) s=0.06;
else if(hits>=4) s=0.04;
else if(hits>=3) s=0.02;
console.log(s);
" 2>/dev/null)
echo "Gate2: ${G2:-0}"
add_reward "${G2:-0}"

# ============================================================
# F2P Gate 3 (weight 0.10): Memo references the actual buggy code locations
# Requires the agent's text to mention specific files. No-op → 0.
# ============================================================
echo ""
echo "=== F2P Gate 3: File references (max 0.10) ==="
G3=$(node -e "
const fs=require('fs');
let t='';try{t=fs.readFileSync('/tmp/memo_content.txt','utf8').toLowerCase();}catch(e){}
if(t.length<800){console.log(0);process.exit(0);}
const refs=[
  /agent-loop\.ts/,
  /interactive-mode\.ts/,
  /(extensions\/runner\.ts|core\/extensions)/,
  /executetoolcallsparallel|executetoolcalls/,
  /showextensionselector|showextensioninput|showextensioneditor|extensionselector|editorcontainer/,
];
let hits=0;
for(const r of refs) if(r.test(t)) hits++;
let s=0;
if(hits>=5) s=0.10;
else if(hits>=4) s=0.07;
else if(hits>=3) s=0.05;
else if(hits>=2) s=0.025;
console.log(s);
" 2>/dev/null)
echo "Gate3: ${G3:-0}"
add_reward "${G3:-0}"

# ============================================================
# F2P Gate 4 (weight 0.20): Code fix wires a serialization mechanism
# into the buggy hotspot. No-op (no diff) → 0.
# Accept multiple valid approaches:
#   - dialogQueue / _uiDialogQueue field on InteractiveMode
#   - withSerializedDialogs / enqueueDialog wrapper in runner.ts
#   - Promise chain that serializes showExtension* calls
# ============================================================
echo ""
echo "=== F2P Gate 4: Serialization wired into source (max 0.20) ==="
G4=0

if [ "$DIFF_LINES" -gt 0 ]; then
  IM_DIFF=$(cd "$REPO" && git diff HEAD -- "packages/coding-agent/src/modes/interactive/interactive-mode.ts" 2>/dev/null)
  RUN_DIFF=$(cd "$REPO" && git diff HEAD -- "packages/coding-agent/src/core/extensions/runner.ts" 2>/dev/null)

  IM_HAS_QUEUE=0
  if echo "$IM_DIFF" | grep -qE "(dialogQueue|_uiDialogQueue|enqueueDialog)"; then
    IM_HAS_QUEUE=1
  fi
  if [ "$IM_HAS_QUEUE" -eq 0 ] && echo "$IM_DIFF" | grep -qE "showExtension(Selector|Input|Editor|Custom)" \
        && echo "$IM_DIFF" | grep -qE "\.then\(|Promise\.resolve\(\)"; then
    IM_HAS_QUEUE=1
  fi

  RUN_HAS_QUEUE=0
  if echo "$RUN_DIFF" | grep -qE "(withSerializedDialogs|enqueueDialog|dialogQueue)"; then
    RUN_HAS_QUEUE=1
  fi
  if [ "$RUN_HAS_QUEUE" -eq 0 ] && echo "$RUN_DIFF" | grep -qE "(select|confirm|input|editor|custom)" \
        && echo "$RUN_DIFF" | grep -qE "(tail|queue|\.then\()"; then
    RUN_HAS_QUEUE=1
  fi

  echo "interactive-mode.ts has queue: $IM_HAS_QUEUE"
  echo "runner.ts has queue: $RUN_HAS_QUEUE"

  if [ "$IM_HAS_QUEUE" -eq 1 ] || [ "$RUN_HAS_QUEUE" -eq 1 ]; then
    G4=0.20
  fi
fi
echo "Gate4: $G4"
add_reward "$G4"

# ============================================================
# F2P Gate 5 (weight 0.20): Fix actually serializes — behavioral check
# Statically verify in CURRENT (post-patch) source that:
#   - InteractiveMode has a dialog queue field AND its showExtension*
#     methods route through it
#   OR
#   - runner.ts wraps ui context with a per-call queue that chains promises
# This passes only if the fix is structurally complete enough to actually
# serialize. No-op base lacks both → 0.
# ============================================================
echo ""
echo "=== F2P Gate 5: Serialization is actually structural (max 0.20) ==="
G5=0

# Path A: InteractiveMode-internal queue
IM_FIELD=$(grep -cE "(dialogQueue|_uiDialogQueue)\s*[:=]" "$INTERACTIVE_TS" 2>/dev/null)
IM_USED=$(grep -cE "(dialogQueue|_uiDialogQueue|enqueueDialog)" "$INTERACTIVE_TS" 2>/dev/null)
# Need at least 3 references (declaration + multiple showExtension* sites)
echo "InteractiveMode queue-field decls: $IM_FIELD, total refs: $IM_USED"

# Path B: Runner-side wrapping
RUN_WRAP=$(grep -cE "(withSerializedDialogs|enqueueDialog)" "$RUNNER_TS" 2>/dev/null)
RUN_QUEUE=$(grep -cE "(dialogQueue|tail\s*=\s*tail\.then|tail:\s*Promise)" "$RUNNER_TS" 2>/dev/null)
echo "Runner wrap refs: $RUN_WRAP, queue refs: $RUN_QUEUE"

PATH_A=0
if [ "$IM_FIELD" -ge 1 ] && [ "$IM_USED" -ge 3 ]; then
  PATH_A=1
fi

PATH_B=0
if [ "$RUN_WRAP" -ge 2 ] || [ "$RUN_QUEUE" -ge 2 ]; then
  PATH_B=1
fi

if [ "$PATH_A" -eq 1 ] || [ "$PATH_B" -eq 1 ]; then
  G5=0.20
fi
echo "Gate5: $G5 (PATH_A=$PATH_A, PATH_B=$PATH_B)"
add_reward "$G5"

# ============================================================
# F2P Gate 6 (weight 0.15): Regression test added that exercises
# concurrent interactive dialogs. The test must be a NEW file (untracked)
# AND mention concurrent/parallel dialog semantics. No-op → 0.
# ============================================================
echo ""
echo "=== F2P Gate 6: Regression test added (max 0.15) ==="
G6=0
NEW_TEST_HIT=0
for nf in $NEW_FILES; do
  case "$nf" in
    *test*.ts|*spec*.ts|*.test.ts|*.spec.ts) ;;
    *) continue ;;
  esac
  full="$REPO/$nf"
  [ -f "$full" ] || continue
  if grep -qiE "(parallel|concurrent|stall|deadlock|orphan|serialize|queue|dialog)" "$full" 2>/dev/null \
     && grep -qiE "(showExtension|extensionSelector|ctx\.ui|confirm|select|interactive)" "$full" 2>/dev/null; then
    echo "Regression test: $nf"
    NEW_TEST_HIT=1
  fi
done
if [ "$NEW_TEST_HIT" -eq 1 ]; then
  G6=0.15
fi
echo "Gate6: $G6"
add_reward "$G6"

# ============================================================
# F2P Gate 7 (weight 0.15): The fix mentions multiple solution options
# AND oracle consultation in the agent text (the instruction explicitly
# requires options A-D + oracle). No-op (no agent text) → 0.
# ============================================================
echo ""
echo "=== F2P Gate 7: Options + oracle in agent output (max 0.15) ==="
G7=$(node -e "
const fs=require('fs');
let t='';try{t=fs.readFileSync('/tmp/memo_content.txt','utf8').toLowerCase();}catch(e){}
if(t.length<800){console.log(0);process.exit(0);}
let optionCount=0;
for(const r of [/option\s*a\b/, /option\s*b\b/, /option\s*c\b/, /option\s*d\b/]){
  if(r.test(t)) optionCount++;
}
const hasOracle=/oracle/.test(t);
const hasRec=/recommend(ation|ed)/.test(t);
const hasReproduc=/reproduc/.test(t);
let s=0;
if(optionCount>=4 && hasOracle && hasRec && hasReproduc) s=0.15;
else if(optionCount>=3 && hasOracle && hasRec) s=0.10;
else if(optionCount>=2 && (hasOracle||hasRec)) s=0.06;
else if(optionCount>=1) s=0.03;
console.log(s);
" 2>/dev/null)
echo "Gate7: ${G7:-0}"
add_reward "${G7:-0}"

# ============================================================
# Final
# ============================================================
echo ""
echo "=== FINAL REWARD: $REWARD ==="
finish