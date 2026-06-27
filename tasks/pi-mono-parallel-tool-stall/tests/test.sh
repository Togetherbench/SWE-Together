#!/bin/bash
# pi-mono-parallel-tool-stall — broadened verifier (rescue from DROP).
#
# DROP rationale was: upstream rejected the agent's workaround. Per the rescue
# rubric, we score the agent's deliverables, not the merge status.
#
# Agent's session produced TWO concrete deliverables:
#   D1: a config-flag fix that makes interactive tool execution sequential.
#       Canonical landed it as `toolExecution: "sequential"` in
#       packages/coding-agent/src/core/sdk.ts. We accept that AND any other
#       wiring (queue/mutex/promise-chain) at the dialog layer that achieves
#       the same effect.
#   D2: a new test file under packages/coding-agent/test/ that fires two
#       interactive tools in one turn (ctx.ui.input/select/confirm), wired to
#       real production classes (createAgentSession / InteractiveMode /
#       ExtensionRunner) — not mocks/recreations.
#
# Gate design is implementation-agnostic: ANY of {sdk.ts toolExecution flag,
# serialization primitive in interactive-mode.ts/runner.ts, agent-loop sequential
# branch} wins the "fix wired" gate.

set +e

mkdir -p /logs/verifier
GATES_FILE=/logs/verifier/gates.json
: > "$GATES_FILE"

emit() {
    local id="$1" passed="$2" detail="${3:-}"
    detail=$(printf '%s' "$detail" | sed 's/"/\\"/g' | tr -d '\n' | head -c 200)
    printf '{"id":"%s","passed":%s,"detail":"%s"}\n' "$id" "$passed" "$detail" >> "$GATES_FILE"
}

REPO=/workspace/pi-mono
if [ ! -d "$REPO" ]; then
  for cand in /workspace/repo /workspace/pi-mono-* ; do
    [ -d "$cand" ] && REPO="$cand" && break
  done
fi
git config --global --add safe.directory "$REPO" 2>/dev/null || true

export PATH="/usr/local/cargo/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
for p in /root/.bun/bin /root/.nvm/versions/node/*/bin /usr/local/share/npm/bin /opt/homebrew/bin ; do
  [ -d "$p" ] && export PATH="$p:$PATH"
done

SDK_TS="$REPO/packages/coding-agent/src/core/sdk.ts"
INTERACTIVE_TS="$REPO/packages/coding-agent/src/modes/interactive/interactive-mode.ts"
RUNNER_TS="$REPO/packages/coding-agent/src/core/extensions/runner.ts"
AGENT_LOOP_TS="$REPO/packages/agent/src/agent-loop.ts"

# ============================================================
# P2P_REGRESSION: source files intact (not nuked by agent)
# ============================================================
P2P_OK=true
for f in "$SDK_TS" "$INTERACTIVE_TS" "$RUNNER_TS" "$AGENT_LOOP_TS"; do
  if [ -f "$f" ]; then
    SIZE=$(wc -c < "$f" 2>/dev/null || echo 0)
    if [ "$SIZE" -lt 500 ]; then
      P2P_OK=false
      emit p2p_src_files_intact false "file truncated: $f"
      break
    fi
  fi
done
if [ "$P2P_OK" = "true" ]; then
  emit p2p_src_files_intact true ""
fi

# ============================================================
# Aggregate the agent's edits: untracked files + diff additions
# ============================================================
: > /tmp/new_test_files.txt
: > /tmp/new_md_content.txt
: > /tmp/diff_added.txt
: > /tmp/all_added_text.txt

if [ -d "$REPO/.git" ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    full="$REPO/$f"
    [ -f "$full" ] || continue
    case "$f" in
      *node_modules/*|*.git/*|*dist/*|*/CHANGELOG*) continue ;;
    esac
    case "$f" in
      *test*.ts|*.test.ts|*.spec.ts|*test*.tsx)
        echo "$f" >> /tmp/new_test_files.txt
        cat "$full" >> /tmp/all_added_text.txt 2>/dev/null
        ;;
      *.md|*.txt|*.MD)
        cat "$full" >> /tmp/new_md_content.txt 2>/dev/null
        cat "$full" >> /tmp/all_added_text.txt 2>/dev/null
        ;;
      *)
        cat "$full" >> /tmp/all_added_text.txt 2>/dev/null
        ;;
    esac
  done < <(cd "$REPO" && git status --porcelain 2>/dev/null | grep -E '^\?\?' | awk '{print $2}')

  (cd "$REPO" && git diff HEAD 2>/dev/null) | grep "^+" | grep -v "^+++" | sed 's/^+//' > /tmp/diff_added.txt
  cat /tmp/diff_added.txt >> /tmp/all_added_text.txt
fi

ADDED_BYTES=$(wc -c < /tmp/all_added_text.txt 2>/dev/null || echo 0)
echo "ADDED_BYTES=$ADDED_BYTES"

# ============================================================
# F2P-1: t1_f2p_fix_wired (weight 0.30)
# Solution-agnostic: ANY of the following counts as a wired fix.
#   (a) sdk.ts gains `toolExecution: "sequential"` (canonical workaround)
#   (b) Serialization primitive added to interactive-mode.ts or runner.ts
#       AND wired into >=2 dialog methods
#   (c) agent-loop.ts gains a `sequential` branch / Promise chain that
#       replaces a Promise.all over tool calls
# ============================================================
G_FIX_WIRED=false
WIRED_DETAIL=""

# Path (a): toolExecution flag in sdk.ts diff/file
if [ -s /tmp/diff_added.txt ] && grep -qE 'toolExecution\s*:\s*["'"'"']sequential["'"'"']' /tmp/diff_added.txt; then
  G_FIX_WIRED=true
  WIRED_DETAIL="sdk-toolExecution-flag"
fi
# Also accept presence in the post-state file even if diff capture missed it
if [ "$G_FIX_WIRED" = "false" ] && [ -f "$SDK_TS" ] && grep -qE 'toolExecution\s*:\s*["'"'"']sequential["'"'"']' "$SDK_TS"; then
  # Confirm it wasn't there pre-change
  if [ -d "$REPO/.git" ]; then
    if ! (cd "$REPO" && git show HEAD:packages/coding-agent/src/core/sdk.ts 2>/dev/null | grep -qE 'toolExecution\s*:\s*["'"'"']sequential["'"'"']'); then
      G_FIX_WIRED=true
      WIRED_DETAIL="sdk-toolExecution-flag-postfile"
    fi
  fi
fi

# Path (b): serialization primitive in interactive-mode.ts / runner.ts wired to dialog methods
if [ "$G_FIX_WIRED" = "false" ]; then
  for f in "$INTERACTIVE_TS" "$RUNNER_TS"; do
    [ -f "$f" ] || continue
    if grep -qE "(dialogQueue|uiQueue|_uiDialogQueue|dialogTail|enqueueDialog|withSerializedDialogs|serializeDialog|dialogChain|prevDialog|interactiveQueue|_pendingDialog)" "$f"; then
      WIRED_METHODS=0
      for m in select confirm input editor showExtensionSelector showExtensionInput; do
        if awk -v m="$m" '
          $0 ~ ("(async )?" m "\\s*\\(") { in_method=1; brace=0 }
          in_method {
            print
            for (i=1;i<=length($0);i++) { c=substr($0,i,1); if (c=="{") brace++; else if (c=="}") brace-- }
            if (brace<=0 && /}/) in_method=0
          }
        ' "$f" 2>/dev/null | grep -qE "(dialogQueue|uiQueue|_uiDialogQueue|dialogTail|enqueueDialog|withSerializedDialogs|serializeDialog|dialogChain|prevDialog|interactiveQueue|_pendingDialog|\.then\()"; then
          WIRED_METHODS=$((WIRED_METHODS+1))
        fi
      done
      if [ "$WIRED_METHODS" -ge 2 ]; then
        G_FIX_WIRED=true
        WIRED_DETAIL="serialization-primitive-in-$(basename "$f")-${WIRED_METHODS}-methods"
        break
      fi
    fi
  done
fi

# Path (c): agent-loop sequential branch
if [ "$G_FIX_WIRED" = "false" ] && [ -f "$AGENT_LOOP_TS" ]; then
  if grep -qE '"sequential"|toolExecution\s*===\s*["'"'"']sequential["'"'"']' "$AGENT_LOOP_TS"; then
    if [ -d "$REPO/.git" ]; then
      if ! (cd "$REPO" && git show HEAD:packages/agent/src/agent-loop.ts 2>/dev/null | grep -qE '"sequential"|toolExecution\s*===\s*["'"'"']sequential["'"'"']'); then
        G_FIX_WIRED=true
        WIRED_DETAIL="agent-loop-sequential-branch"
      fi
    fi
  fi
fi

if [ "$G_FIX_WIRED" = "true" ]; then
  emit t1_f2p_fix_wired true "$WIRED_DETAIL"
else
  emit t1_f2p_fix_wired false "no sequential-execution fix found in sdk.ts / interactive-mode.ts / runner.ts / agent-loop.ts"
fi

# ============================================================
# F2P-2: t2_f2p_concurrency_test_exists (weight 0.20)
# A new test file is added under packages/coding-agent/test/ (or anywhere)
# that exercises two interactive tool/dialog calls concurrently.
# ============================================================
G_TEST_EXISTS=false
G_TEST_FILES=""
if [ -s /tmp/new_test_files.txt ]; then
  while IFS= read -r tf; do
    [ -z "$tf" ] && continue
    full="$REPO/$tf"
    [ -f "$full" ] || continue
    LC=$(tr '[:upper:]' '[:lower:]' < "$full")
    has_concurrency=0; has_dialog=0
    # Concurrency: literal Promise.all OR two interactive tools fired in one
    # turn (toolCall ask_a + ask_b pattern from the canonical test).
    if echo "$LC" | grep -qE "promise\.all|concurrent|toolcall.*toolcall|ask_a.*ask_b|both interactive tools|interactive.*concurrency"; then
      has_concurrency=1
    fi
    # Two distinct ctx.ui.* / ui.* / *.input(...) calls also count as concurrency
    UI_CALLS=$(echo "$LC" | grep -cE "(ctx\.ui\.|ui\.)(input|select|confirm|editor)\s*\(")
    if [ "$UI_CALLS" -ge 2 ]; then
      has_concurrency=1
    fi
    # Two toolCall objects in the same source = two parallel tool calls
    TOOLCALL_COUNT=$(grep -cE 'type:\s*"toolCall"' "$full" 2>/dev/null || echo 0)
    if [ "$TOOLCALL_COUNT" -ge 2 ]; then
      has_concurrency=1
    fi
    if echo "$LC" | grep -qE "(ctx\.ui\.|ui\.)(input|select|confirm|editor)|interactive.*tool|asktool|tool.*concurrency"; then
      has_dialog=1
    fi
    if [ $has_concurrency -eq 1 ] && [ $has_dialog -eq 1 ]; then
      G_TEST_EXISTS=true
      G_TEST_FILES="$G_TEST_FILES $tf"
    fi
  done < /tmp/new_test_files.txt
fi
if [ "$G_TEST_EXISTS" = "true" ]; then
  emit t2_f2p_concurrency_test_exists true "$G_TEST_FILES"
else
  emit t2_f2p_concurrency_test_exists false "no new test exercises two concurrent interactive tool/dialog calls"
fi

# ============================================================
# F2P-3: t3_f2p_test_drives_both (weight 0.15)
# The added test must drive BOTH submissions, not just one. Either:
#   - Promise.all over two awaited dialog calls
#   - Two toolCall objects fired together (canonical streamFn pattern)
#   - Two distinct ctx.ui.input/select/confirm calls awaited
# ============================================================
G_DRIVES_BOTH=false
if [ -n "$G_TEST_FILES" ]; then
  for tf in $G_TEST_FILES; do
    full="$REPO/$tf"
    [ -f "$full" ] || continue
    LC=$(tr '[:upper:]' '[:lower:]' < "$full")
    drives=0
    # Pattern 1: Promise.all over two awaits
    if echo "$LC" | grep -qE "promise\.all\s*\(\s*\["; then
      drives=1
    fi
    # Pattern 2: Two toolCall entries in a streamFn / mock LLM
    TOOLCALL_COUNT=$(grep -cE 'type:\s*"toolCall"' "$full" 2>/dev/null || echo 0)
    if [ "$TOOLCALL_COUNT" -ge 2 ]; then
      drives=1
    fi
    # Pattern 3: ask_a and ask_b (canonical naming) both invoked
    if echo "$LC" | grep -qE "ask_a" && echo "$LC" | grep -qE "ask_b"; then
      drives=1
    fi
    # Pattern 4: explicit two awaited dialog calls
    UI_CALLS=$(echo "$LC" | grep -cE "(ctx\.ui\.|ui\.)(input|select|confirm|editor)\s*\(")
    if [ "$UI_CALLS" -ge 2 ]; then
      drives=1
    fi
    if [ "$drives" -eq 1 ]; then
      G_DRIVES_BOTH=true
      break
    fi
  done
fi
if [ "$G_DRIVES_BOTH" = "true" ]; then
  emit t3_f2p_test_drives_both true ""
else
  emit t3_f2p_test_drives_both false "test does not drive both submissions"
fi

# ============================================================
# F2P-4: t4_f2p_test_imports_real_code (weight 0.20)
# The added test imports real production classes from src — not mocks /
# local recreations. Per the user's T15 message: "use as much stuff from
# the code as possible and not mock/recrete shit too much".
# Accept any of: createAgentSession, InteractiveMode, ExtensionRunner,
# AgentLoop, or imports from ../src/.
# ============================================================
G_REAL_IMPORTS=false
G_REAL_IMPORT_DETAIL=""
if [ -s /tmp/new_test_files.txt ]; then
  while IFS= read -r tf; do
    [ -z "$tf" ] && continue
    full="$REPO/$tf"
    [ -f "$full" ] || continue
    if grep -qE "from\s+[\"'][^\"']*(createAgentSession|interactive-mode|extensions/runner|agent-loop|ExtensionRunner|InteractiveMode|sdk\.js|sdk\.ts|core/sdk)" "$full"; then
      G_REAL_IMPORTS=true
      G_REAL_IMPORT_DETAIL="src-path-import"
      break
    fi
    if grep -qE "import\s+\{[^}]*(createAgentSession|InteractiveMode|ExtensionRunner|AgentLoop)[^}]*\}" "$full"; then
      G_REAL_IMPORTS=true
      G_REAL_IMPORT_DETAIL="named-import"
      break
    fi
    # Relative imports into src/
    if grep -qE "from\s+[\"'](\.\.\/)+src/" "$full"; then
      G_REAL_IMPORTS=true
      G_REAL_IMPORT_DETAIL="relative-src-import"
      break
    fi
  done < /tmp/new_test_files.txt
fi
if [ "$G_REAL_IMPORTS" = "true" ]; then
  emit t4_f2p_test_imports_real_code true "$G_REAL_IMPORT_DETAIL"
else
  emit t4_f2p_test_imports_real_code false "no new test imports real code from src/"
fi

# ============================================================
# F2P-5: t5_f2p_concept_coverage (weight 0.15)
# Across the agent's edits (test files, memo, diff additions), at least
# 3 of these 4 concept groups must appear. This rewards coherent
# investigation/explanation alongside the fix.
#   G1: parallel / Promise.all / concurrent
#   G2: sequential / serialize / queue / chain
#   G3: interactive / dialog / ctx.ui / extension UI
#   G4: stall / orphan / hang / never resolves / deadlock
# ============================================================
G_CONCEPT=false
if [ "$ADDED_BYTES" -ge 200 ]; then
  CONCEPT_HITS=$(node -e '
    const fs=require("fs");
    let t="";try{t=fs.readFileSync("/tmp/all_added_text.txt","utf8").toLowerCase();}catch(e){}
    const groups=[
      [/parallel/, /promise\.all/, /concurren(t|cy)/, /two.*tool.*call/, /both.*tool/],
      [/sequential/, /serial(ize|ised|ized)?/, /queue/, /mutex/, /chain/, /toolexecution/],
      [/interactive/, /dialog/, /ctx\.ui/, /extensionuicontext/, /\.ui\.(input|select|confirm|editor)/],
      [/stall/, /orphan/, /\bhang/, /deadlock/, /never\s+resolv/, /never\s+settle/, /timeout/],
    ];
    let hits=0;
    for(const g of groups){ if(g.some(r=>r.test(t))) hits++; }
    console.log(hits);
  ' 2>/dev/null)
  CONCEPT_HITS=${CONCEPT_HITS:-0}
  if [ "$CONCEPT_HITS" -ge 3 ]; then
    G_CONCEPT=true
  fi
fi
if [ "$G_CONCEPT" = "true" ]; then
  emit t5_f2p_concept_coverage true ""
else
  emit t5_f2p_concept_coverage false "added text fails to cover >=3 concept groups (parallel/sequential/interactive/stall)"
fi

# ============================================================
# Reward — weighted-replace formula (per CLAUDE.md / commit c8bc168a)
# WEIGHTS sum to 1.00; legacy inner reward (none here) is fully subsumed.
# ============================================================
python3 - <<'PYEOF'
import json, os

WEIGHTS = {
    "t1_f2p_fix_wired":               0.30,
    "t2_f2p_concurrency_test_exists": 0.20,
    "t3_f2p_test_drives_both":        0.15,
    "t4_f2p_test_imports_real_code":  0.20,
    "t5_f2p_concept_coverage":        0.15,
}
P2P_REGRESSION = ["p2p_src_files_intact"]
P2P_REGRESSION = []  # informational only; no upstream regression gates wired here

verdicts = {}
try:
    with open('/logs/verifier/gates.json') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try:
                d = json.loads(line)
                gid = d.get('id')
                if gid:
                    verdicts[gid] = bool(d.get('passed'))
            except Exception:
                pass
except FileNotFoundError:
    pass

# P2P failures are diagnostics/penalty inputs only.

# Read existing reward (none here, but keep the pattern)
existing = 0.0
try:
    with open('/logs/verifier/reward.txt') as f:
        existing = float(f.read().strip() or 0)
except Exception:
    pass

f2p_any_pass = any(verdicts.get(gid, False) for gid in WEIGHTS)

if (not f2p_any_pass and existing <= 0):
    reward = 0.0
else:
    inner_share = max(0.0, 1.0 - sum(float(w) for w in WEIGHTS.values()))
    reward = existing * inner_share
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid, False):
            reward += float(w)

reward = max(0.0, min(1.0, reward))
os.makedirs('/logs/verifier', exist_ok=True)
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write('%.4f\n' % reward)
print('REWARD=%.4f' % reward)
print('GATES=' + json.dumps(verdicts))
PYEOF

cat /logs/verifier/reward.txt
echo "=== Gates ==="
cat "$GATES_FILE"
exit 0
