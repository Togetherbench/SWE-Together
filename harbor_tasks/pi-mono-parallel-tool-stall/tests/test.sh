#!/bin/bash
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

INTERACTIVE_TS="$REPO/packages/coding-agent/src/modes/interactive/interactive-mode.ts"
RUNNER_TS="$REPO/packages/coding-agent/src/core/extensions/runner.ts"
AGENT_LOOP_TS="$REPO/packages/agent/src/agent-loop.ts"

# ============================================================
# P2P: source file integrity
# ============================================================
P2P_OK=true
for f in "$INTERACTIVE_TS" "$RUNNER_TS" "$AGENT_LOOP_TS"; do
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
# Aggregate agent-produced text: memo + new tests + diff additions
# ============================================================
: > /tmp/memo_content.txt
: > /tmp/new_test_files.txt
: > /tmp/diff_added.txt

if [ -d "$REPO/.git" ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    full="$REPO/$f"
    [ -f "$full" ] || continue
    case "$f" in
      *node_modules/*|*.git/*|*dist/*|*/CHANGELOG*) continue ;;
    esac
    case "$f" in
      *.md|*.txt|*.MD)
        cat "$full" >> /tmp/memo_content.txt 2>/dev/null
        echo "" >> /tmp/memo_content.txt
        ;;
      *test*.ts|*.test.ts|*.spec.ts|*test*.tsx)
        echo "$f" >> /tmp/new_test_files.txt
        cat "$full" >> /tmp/memo_content.txt 2>/dev/null
        ;;
      *)
        cat "$full" >> /tmp/memo_content.txt 2>/dev/null
        ;;
    esac
  done < <(cd "$REPO" && git status --porcelain 2>/dev/null | grep -E '^\?\?' | awk '{print $2}')

  (cd "$REPO" && git diff HEAD 2>/dev/null) | grep "^+" | grep -v "^+++" | sed 's/^+//' > /tmp/diff_added.txt
  cat /tmp/diff_added.txt >> /tmp/memo_content.txt
fi

# Diff stats for hotspot files
RUNNER_DIFF=0
INTERACTIVE_DIFF=0
AGENT_DIFF=0
if [ -d "$REPO/.git" ]; then
  RUNNER_DIFF=$(cd "$REPO" && git diff HEAD -- "packages/coding-agent/src/core/extensions/runner.ts" 2>/dev/null | wc -l)
  INTERACTIVE_DIFF=$(cd "$REPO" && git diff HEAD -- "packages/coding-agent/src/modes/interactive/interactive-mode.ts" 2>/dev/null | wc -l)
  AGENT_DIFF=$(cd "$REPO" && git diff HEAD -- "packages/agent/src/agent-loop.ts" 2>/dev/null | wc -l)
fi
HOTSPOT_DIFF=$((RUNNER_DIFF + INTERACTIVE_DIFF + AGENT_DIFF))
echo "RUNNER_DIFF=$RUNNER_DIFF INTERACTIVE_DIFF=$INTERACTIVE_DIFF AGENT_DIFF=$AGENT_DIFF"

# Detect serialization-related additions in DIFF (not just file presence)
SERIAL_PRIM_IN_DIFF=0
DIALOG_WIRED_IN_DIFF=0
if [ -s /tmp/diff_added.txt ]; then
  if grep -qE "(dialogQueue|uiQueue|_uiDialogQueue|dialogTail|enqueueDialog|withSerializedDialogs|serializeDialog|chainPromise|dialogChain|interactiveQueue|_pendingDialog|prevDialog)" /tmp/diff_added.txt; then
    SERIAL_PRIM_IN_DIFF=1
  fi
  # Or generic promise-chain serialization pattern
  if grep -qE "this\.[a-zA-Z_]*[Tt]ail\s*=" /tmp/diff_added.txt && grep -qE "\.then\(" /tmp/diff_added.txt; then
    SERIAL_PRIM_IN_DIFF=1
  fi
  if grep -qE "(showExtensionSelector|showExtensionInput|showExtensionEditor|showExtensionCustom|ui\.confirm|ui\.select|ui\.input|ui\.editor|ctx\.ui)" /tmp/diff_added.txt; then
    DIALOG_WIRED_IN_DIFF=1
  fi
fi

# ============================================================
# t1_f2p_memo_root_cause
# Memo must hit ALL FOUR concept groups (root cause language).
# ============================================================
MEMO_LEN=$(wc -c < /tmp/memo_content.txt 2>/dev/null || echo 0)
G1_PASS=false
if [ "$MEMO_LEN" -ge 1500 ]; then
  CONCEPT_HITS=$(node -e '
    const fs=require("fs");
    let t="";try{t=fs.readFileSync("/tmp/memo_content.txt","utf8").toLowerCase();}catch(e){}
    const groups=[
      [/parallel/, /promise\.all/, /executetoolcallsparallel/, /concurrent/],
      [/sequential|serial(ize|ised|ized)?|queue|mutex|enqueue|chain/],
      [/interactive|dialog|extensionselector|extensioninput|extensioneditor|extensioncustom|ctx\.ui|ui\.confirm|ui\.select|showextension/],
      [/orphan|stall|hang|deadlock|race|overwrit|clobber|never\s+resolv|never\s+settle/],
    ];
    let hits=0;
    for(const g of groups){ if(g.some(r=>r.test(t))) hits++; }
    console.log(hits);
  ' 2>/dev/null)
  CONCEPT_HITS=${CONCEPT_HITS:-0}
  if [ "$CONCEPT_HITS" -ge 4 ]; then
    G1_PASS=true
  fi
fi
if [ "$G1_PASS" = "true" ]; then
  emit t1_f2p_memo_root_cause true ""
else
  emit t1_f2p_memo_root_cause false "memo missing required root-cause concepts (parallel + serialize + interactive-dialog + stall/orphan)"
fi

# ============================================================
# t1_f2p_memo_hotspot_refs
# Memo must reference the concrete files.
# ============================================================
G2_PASS=false
if [ -s /tmp/memo_content.txt ]; then
  HF=0
  grep -qiE "interactive-mode\.ts|interactive-mode" /tmp/memo_content.txt && HF=$((HF+1))
  grep -qiE "runner\.ts|extensions/runner" /tmp/memo_content.txt && HF=$((HF+1))
  grep -qiE "agent-loop\.ts" /tmp/memo_content.txt && HF=$((HF+1))
  if [ "$HF" -ge 2 ]; then
    G2_PASS=true
  fi
fi
if [ "$G2_PASS" = "true" ]; then
  emit t1_f2p_memo_hotspot_refs true ""
else
  emit t1_f2p_memo_hotspot_refs false "memo lacks references to >=2 hotspot files"
fi

# ============================================================
# t2_f2p_failing_test_exists
# A new test file exists that exercises parallel + dialog concept.
# ============================================================
G3_PASS=false
G3_TEST_FILES=""
if [ -s /tmp/new_test_files.txt ]; then
  while IFS= read -r tf; do
    [ -z "$tf" ] && continue
    full="$REPO/$tf"
    [ -f "$full" ] || continue
    LC=$(tr '[:upper:]' '[:lower:]' < "$full")
    has_parallel=0; has_dialog=0
    echo "$LC" | grep -qE "promise\.all|parallel|concurrent" && has_parallel=1
    echo "$LC" | grep -qE "confirm|select|input|editor|extensionselector|showextension|ctx\.ui|dialog" && has_dialog=1
    if [ $has_parallel -eq 1 ] && [ $has_dialog -eq 1 ]; then
      G3_PASS=true
      G3_TEST_FILES="$G3_TEST_FILES $tf"
    fi
  done < /tmp/new_test_files.txt
fi
if [ "$G3_PASS" = "true" ]; then
  emit t2_f2p_failing_test_exists true ""
else
  emit t2_f2p_failing_test_exists false "no new test file exercises parallel + interactive dialog"
fi

# ============================================================
# t2_f2p_test_asserts_both_resolve
# Test must contain a Promise.all over two dialog awaits AND assert both settle.
# ============================================================
G4_PASS=false
if [ -n "$G3_TEST_FILES" ]; then
  for tf in $G3_TEST_FILES; do
    full="$REPO/$tf"
    [ -f "$full" ] || continue
    LC=$(tr '[:upper:]' '[:lower:]' < "$full")
    asserts_both=0
    if echo "$LC" | grep -qE "tohavelength\(2\)|\.length.*===.*2|\[.*,.*\].*=.*await\s+promise\.all|results.*tohaveLength" ; then
      asserts_both=1
    fi
    # Or: two awaited dialog calls with destructured Promise.all
    if echo "$LC" | grep -qE "promise\.all\s*\(\s*\["; then
      asserts_both=1
    fi
    # Or: explicit two ctx.ui.* calls captured into separate vars then awaited
    DIALOG_CALL_COUNT=$(echo "$LC" | grep -cE "(ctx\.ui\.|ui\.)(confirm|select|input|editor)\s*\(")
    if [ "$DIALOG_CALL_COUNT" -ge 2 ]; then
      asserts_both=1
    fi
    if [ "$asserts_both" -eq 1 ]; then
      G4_PASS=true
      break
    fi
  done
fi
if [ "$G4_PASS" = "true" ]; then
  emit t2_f2p_test_asserts_both_resolve true ""
else
  emit t2_f2p_test_asserts_both_resolve false "test does not assert both dialog calls settle / no Promise.all over two dialogs"
fi

# ============================================================
# t11_f2p_serialization_primitive_wired
# Serialization primitive in DIFF + wired to dialog methods.
# Reject if only declared without usage. Verify multiple call sites use it.
# ============================================================
G5_PASS=false
if [ "$SERIAL_PRIM_IN_DIFF" -eq 1 ] && [ "$DIALOG_WIRED_IN_DIFF" -eq 1 ]; then
  # Now verify wiring: in the post-fix file, count dialog methods that
  # reference a queue/chain identifier nearby.
  WIRED_METHOD_COUNT=0
  for f in "$INTERACTIVE_TS" "$RUNNER_TS"; do
    [ -f "$f" ] || continue
    # Find queue identifiers used in this file
    if grep -qE "(dialogQueue|uiQueue|_uiDialogQueue|dialogTail|enqueueDialog|withSerializedDialogs|serializeDialog|dialogChain|prevDialog|interactiveQueue|_pendingDialog)" "$f"; then
      # Count distinct dialog method bodies that use the queue/enqueue helper
      for m in select confirm input editor showExtensionSelector showExtensionInput showExtensionEditor showExtensionCustom; do
        # Extract a window around each method definition and check for queue refs
        if awk -v m="$m" '
          $0 ~ ("(async )?" m "\\s*\\(") { in_method=1; brace=0 }
          in_method {
            print
            for (i=1;i<=length($0);i++) { c=substr($0,i,1); if (c=="{") brace++; else if (c=="}") brace-- }
            if (brace<=0 && /}/) in_method=0
          }
        ' "$f" 2>/dev/null | grep -qE "(dialogQueue|uiQueue|_uiDialogQueue|dialogTail|enqueueDialog|withSerializedDialogs|serializeDialog|dialogChain|prevDialog|interactiveQueue|_pendingDialog|\.then\()"; then
          WIRED_METHOD_COUNT=$((WIRED_METHOD_COUNT+1))
        fi
      done
    fi
  done
  if [ "$WIRED_METHOD_COUNT" -ge 3 ]; then
    G5_PASS=true
  fi
fi
if [ "$G5_PASS" = "true" ]; then
  emit t11_f2p_serialization_primitive_wired true ""
else
  emit t11_f2p_serialization_primitive_wired false "no serialization primitive wired through >=3 dialog methods"
fi

# ============================================================
# t11_f2p_behavioral_serializes
# Build a Node harness that imports the actual modified module via tsx
# (or reads the post-fix runner/interactive-mode source) and observes
# that two concurrent dialog calls serialize (max-concurrency=1, both
# resolve in order). If we can't import (no deps), fall back to a
# source-level data-flow check that the queue identifier is awaited
# BEFORE calling underlying ui method, in >=3 dialog methods.
# ============================================================
G6_PASS=false

HARNESS_DIR=/tmp/serialize_harness
mkdir -p "$HARNESS_DIR"

# Find tsx / ts-node / vitest
TSX_BIN=""
for c in "$REPO/node_modules/.bin/tsx" "$REPO/packages/coding-agent/node_modules/.bin/tsx" \
         "$REPO/node_modules/.bin/ts-node" ; do
  [ -x "$c" ] && TSX_BIN="$c" && break
done
NODE_BIN=$(command -v node 2>/dev/null)

# Try a structural-behavioral check: parse runner.ts/interactive-mode.ts
# and confirm that within each dialog method, the queue identifier is
# AWAITED (or used as a .then chain) before invoking the underlying UI.
behavioral_static_pass() {
  python3 - <<'PYEOF' 2>/dev/null
import os, re, sys

files = [
  os.environ.get("INTERACTIVE_TS",""),
  os.environ.get("RUNNER_TS",""),
]
queue_ids = r"(dialogQueue|uiQueue|_uiDialogQueue|dialogTail|dialogChain|prevDialog|interactiveQueue|_pendingDialog|enqueueDialog|withSerializedDialogs|serializeDialog)"
ui_calls = r"(ui\.|ctx\.ui\.|this\.ui\.)(select|confirm|input|editor|custom)"

method_pat = re.compile(r"(?:async\s+)?(?:private\s+|public\s+|protected\s+)?(showExtensionSelector|showExtensionInput|showExtensionEditor|showExtensionCustom|select|confirm|input|editor)\s*\(")

def find_method_body(text, mstart):
    # find first '{' after mstart
    i = text.find("{", mstart)
    if i < 0: return None
    depth = 0
    j = i
    while j < len(text):
        c = text[j]
        if c == "{": depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return text[i:j+1]
        j += 1
    return None

ok_methods = 0
for f in files:
    if not f or not os.path.exists(f): continue
    with open(f) as fh: text = fh.read()
    if not re.search(queue_ids, text): continue
    for m in method_pat.finditer(text):
        body = find_method_body(text, m.start())
        if not body: continue
        # Method must reference queue id AND either await it or chain .then
        if not re.search(queue_ids, body): continue
        # Look for: await this.<queue>, or this.<queue>.then(, or enqueueDialog(
        awaited = bool(
            re.search(r"await\s+this\.[a-zA-Z_]*[Tt]ail", body) or
            re.search(r"await\s+this\.\w*[Qq]ueue", body) or
            re.search(r"\benqueueDialog\s*\(", body) or
            re.search(r"this\.\w+\.then\s*\(", body) or
            re.search(r"await\s+\w+[Cc]hain", body) or
            re.search(r"await\s+[Pp]rev[Dd]ialog", body) or
            re.search(r"withSerializedDialogs\s*\(", body) or
            re.search(r"serializeDialog\s*\(", body)
        )
        if awaited:
            ok_methods += 1

print(ok_methods)
PYEOF
}

export INTERACTIVE_TS RUNNER_TS

if [ "$SERIAL_PRIM_IN_DIFF" -eq 1 ]; then
  STATIC_OK=$(behavioral_static_pass)
  STATIC_OK=${STATIC_OK:-0}
  echo "Static behavioral check: $STATIC_OK methods serialize"

  # Try a real runtime harness if we have tsx + deps.
  RUNTIME_PASSED=0
  if [ -n "$TSX_BIN" ] && [ -d "$REPO/packages/coding-agent/node_modules" -o -d "$REPO/node_modules" ]; then
    cat > "$HARNESS_DIR/harness.ts" <<'TS'
// Behavioral harness: load the real InteractiveMode/runner code path,
// fire two concurrent dialog calls through whatever serializing wrapper
// exists, observe max-concurrency=1 and both resolve.
import * as path from "path";

const REPO = process.env.REPO!;

async function tryRunner(): Promise<boolean> {
  try {
    const mod = await import(path.join(REPO, "packages/coding-agent/src/core/extensions/runner.ts"));
    const Runner = mod.ExtensionRunner || mod.default;
    if (!Runner) return false;
    const runner: any = new Runner();
    let active = 0, max = 0;
    const order: string[] = [];
    const ui: any = {
      select: async (t: string, opts: string[]) => { active++; max=Math.max(max,active); order.push("s:"+t); await new Promise(r=>setTimeout(r,20)); order.push("e:"+t); active--; return opts[0]; },
      confirm: async (t: string) => { active++; max=Math.max(max,active); await new Promise(r=>setTimeout(r,20)); active--; return true; },
      input: async (t: string) => { active++; max=Math.max(max,active); await new Promise(r=>setTimeout(r,20)); active--; return ""; },
      editor: async (t: string) => { active++; max=Math.max(max,active); await new Promise(r=>setTimeout(r,20)); active--; return ""; },
      custom: async () => { active++; max=Math.max(max,active); await new Promise(r=>setTimeout(r,20)); active--; },
    };
    if (typeof runner.setUIContext === "function") runner.setUIContext(ui);
    let ctx: any = null;
    for (const k of ["getExtensionUIContext","buildExtensionUIContext","extensionUIContext","uiContext","ctx","ui"]) {
      try {
        const v = typeof runner[k] === "function" ? runner[k]() : runner[k];
        if (v && typeof v.select === "function") { ctx = v; break; }
      } catch {}
    }
    if (!ctx) return false;
    const p1 = ctx.select("A", ["x"]);
    const p2 = ctx.select("B", ["y"]);
    const r = await Promise.all([p1, p2]);
    if (r.length !== 2) return false;
    if (max !== 1) return false;
    if (order[0] !== "s:A" || order[1] !== "e:A" || order[2] !== "s:B") return false;
    return true;
  } catch (e) {
    return false;
  }
}

(async () => {
  const ok = await tryRunner();
  console.log(ok ? "HARNESS_PASS" : "HARNESS_FAIL");
  process.exit(ok ? 0 : 1);
})();
TS
    REPO="$REPO" timeout 30 "$TSX_BIN" "$HARNESS_DIR/harness.ts" > "$HARNESS_DIR/out.txt" 2>&1
    if grep -q "HARNESS_PASS" "$HARNESS_DIR/out.txt"; then
      RUNTIME_PASSED=1
    fi
  fi

  if [ "$RUNTIME_PASSED" -eq 1 ]; then
    G6_PASS=true
  elif [ "$STATIC_OK" -ge 3 ]; then
    # No runtime available, but static dataflow shows the queue is
    # awaited in >=3 dialog methods — strong evidence of serialization.
    G6_PASS=true
  fi
fi

if [ "$G6_PASS" = "true" ]; then
  emit t11_f2p_behavioral_serializes true ""
else
  emit t11_f2p_behavioral_serializes false "no behavioral evidence of serialized dialogs"
fi

# ============================================================
# t15_f2p_test_imports_real_code
# New test imports real classes from src (not local re-implementations).
# ============================================================
G7_PASS=false
if [ -s /tmp/new_test_files.txt ]; then
  while IFS= read -r tf; do
    [ -z "$tf" ] && continue
    full="$REPO/$tf"
    [ -f "$full" ] || continue
    # Look for imports referencing real source paths
    if grep -qE "from\s+[\"'][^\"']*(interactive-mode|extensions/runner|agent-loop|ExtensionRunner|InteractiveMode)" "$full"; then
      G7_PASS=true
      break
    fi
    # Or relative import into src
    if grep -qE "from\s+[\"'](\.\.\/)+src/" "$full" || \
       grep -qE "import\s+\{[^}]*(InteractiveMode|ExtensionRunner|AgentLoop)[^}]*\}" "$full"; then
      G7_PASS=true
      break
    fi
  done < /tmp/new_test_files.txt
fi
if [ "$G7_PASS" = "true" ]; then
  emit t15_f2p_test_imports_real_code true ""
else
  emit t15_f2p_test_imports_real_code false "no new test imports real InteractiveMode/ExtensionRunner from src"
fi

# ============================================================
# t16_f2p_test_drives_both_submissions
# Test must drive BOTH submissions concurrently — Promise.all over two
# awaited tool/dialog calls, with both expected to settle (not just one).
# ============================================================
G8_PASS=false
if [ -s /tmp/new_test_files.txt ]; then
  while IFS= read -r tf; do
    [ -z "$tf" ] && continue
    full="$REPO/$tf"
    [ -f "$full" ] || continue
    LC=$(tr '[:upper:]' '[:lower:]' < "$full")
    # Must have Promise.all AND >=2 dialog calls AND assertion that both resolve
    has_promise_all=0; has_two_calls=0; has_both_assert=0
    echo "$LC" | grep -qE "promise\.all" && has_promise_all=1
    CALL_COUNT=$(echo "$LC" | grep -cE "(ctx\.ui\.|ui\.|runner\.|interactivemode|\.confirm\s*\(|\.select\s*\(|\.input\s*\(|\.editor\s*\()")
    if [ "$CALL_COUNT" -ge 2 ]; then has_two_calls=1; fi
    if echo "$LC" | grep -qE "tohavelength\(2\)|results\[0\].*results\[1\]|\[.*r1.*,.*r2.*\]\s*=|expect.*\.tobe\(true\).*expect.*\.tobe\(true\)|both.*resolv|both.*settl"; then
      has_both_assert=1
    fi
    # Promise.all destructure pattern
    if echo "$LC" | grep -qE "(const|let)\s*\[\s*\w+\s*,\s*\w+\s*\]\s*=\s*await\s*promise\.all"; then
      has_both_assert=1
    fi
    if [ $has_promise_all -eq 1 ] && [ $has_two_calls -eq 1 ] && [ $has_both_assert -eq 1 ]; then
      G8_PASS=true
      break
    fi
  done < /tmp/new_test_files.txt
fi
if [ "$G8_PASS" = "true" ]; then
  emit t16_f2p_test_drives_both_submissions true ""
else
  emit t16_f2p_test_drives_both_submissions false "test does not drive both submissions concurrently with assertion that both settle"
fi

# ============================================================
# Compute reward
# ============================================================
REWARD=0
declare -A WEIGHTS=(
  [t1_f2p_memo_root_cause]=0.10
  [t1_f2p_memo_hotspot_refs]=0.05
  [t2_f2p_failing_test_exists]=0.10
  [t2_f2p_test_asserts_both_resolve]=0.05
  [t11_f2p_serialization_primitive_wired]=0.20
  [t11_f2p_behavioral_serializes]=0.30
  [t15_f2p_test_imports_real_code]=0.10
  [t16_f2p_test_drives_both_submissions]=0.10
)

# Check P2P gating
P2P_FAIL=$(grep -E '"id":"p2p_' "$GATES_FILE" | grep -c '"passed":false')

if [ "$P2P_FAIL" -gt 0 ]; then
  REWARD=0
else
  for gate in "${!WEIGHTS[@]}"; do
    if grep -q "\"id\":\"$gate\",\"passed\":true" "$GATES_FILE"; then
      w=${WEIGHTS[$gate]}
      REWARD=$(awk -v a="$REWARD" -v b="$w" 'BEGIN{ printf "%.4f", a+b }')
    fi
  done
fi

printf "%.4f\n" "$REWARD" > /logs/verifier/reward.txt
cat /logs/verifier/reward.txt
echo "=== Gates ==="
cat "$GATES_FILE"
# ---- v042 upstream CI gates (auto-injected) ----
# v043 upstream gates: prelude(s) + per-gate execution.
(
    set +e
    # prelude 0
    echo 'c2V0ICtlOyBjZCAvd29ya3NwYWNlL3BpLW1vbm8gJiYgY29tbWFuZCAtdiBucHggPi9kZXYvbnVsbCAmJiBlY2hvIE9L' | base64 -d | bash 2>&1 | tail -2
) 2>/dev/null

run_v043_gate() {
    local id="$1" label="$2"; shift 2
    local cmd="$*"
    local rc out tail
    out=$(timeout 240 bash -c "$cmd" 2>&1)
    rc=$?
    if [ $rc -eq 0 ]; then
        emit "$id" true ""
    else
        tail="${out: -180}"
        tail="${tail//\"/\'}"
        tail="${tail//$'\n'/ }"
        emit "$id" false "rc=$rc; $tail"
    fi
}
run_v043_gate p2p_upstream_e395cbc7 'npm_typecheck_coding-agent' 'cd /workspace/pi-mono && CHANGED=$((git diff --name-only HEAD~1 HEAD 2>/dev/null; git diff --name-only HEAD 2>/dev/null) | grep -E "^packages/coding-agent/.*\.tsx?$" | sort -u | tr "\n" " "); if [ -z "$CHANGED" ]; then echo "no agent .ts/.tsx changes in packages/coding-agent — gate skipped"; exit 0; fi; cd /workspace/pi-mono && timeout 120 npx tsgo --noEmit $CHANGED 2>&1 | tail -5; rc=$?; if [ $rc -ne 0 ] && [ $rc -ne 124 ]; then exit $rc; fi'
run_v043_gate p2p_upstream_522628b0 'vitest_session_manager_coding-agent' 'cd /workspace/pi-mono && cd /workspace/pi-mono/packages/coding-agent && timeout 120 npx vitest run test/path-utils.test.ts --reporter=basic 2>&1 | tail -10'

# Recompute reward using v043 weights.
python3 - <<"V043_PY"
import json, os
WEIGHTS = {"t11_f2p_behavioral_serializes": 0.3, "t11_f2p_serialization_primitive_wired": 0.2, "t15_f2p_test_imports_real_code": 0.1, "t16_f2p_test_drives_both_submissions": 0.1, "t1_f2p_memo_hotspot_refs": 0.05, "t1_f2p_memo_root_cause": 0.1, "t2_f2p_failing_test_exists": 0.1, "t2_f2p_test_asserts_both_resolve": 0.05}
P2P_GATING = ["p2p_src_files_intact"]
P2P_REGRESSION = ["p2p_upstream_e395cbc7", "p2p_upstream_522628b0"]
verdicts = {}
try:
    with open('/logs/verifier/gates.json') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try:
                d = json.loads(line)
                gid = d.get('id')
                if gid: verdicts[gid] = bool(d.get('passed'))
            except Exception: pass
except FileNotFoundError: pass
hard_zero = False
for gid in P2P_GATING + P2P_REGRESSION:
    if not verdicts.get(gid, False):
        hard_zero = True; break
if hard_zero: reward = 0.0
else:
    reward = 0.0
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid, False): reward += w
    if reward > 1.0: reward = 1.0
os.makedirs('/logs/verifier', exist_ok=True)
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write('%.4f\n' % reward)
print('V043_REWARD=%.4f' % reward)
V043_PY
# ---- v042 end upstream CI gates ----

exit 0