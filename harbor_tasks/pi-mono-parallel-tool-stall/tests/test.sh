#!/bin/bash
set +e

# ============================================================
# Verifier for pi-mono parallel tool stall fix.
#
# The bug: in InteractiveMode (packages/coding-agent/src/modes/interactive/
# interactive-mode.ts), the showExtension* methods (Selector/Input/Editor/
# Custom) all unconditionally do editorContainer.clear() and overwrite
# this.extensionSelector / this.extensionInput / this.extensionEditor.
# When two tools execute in parallel (default Promise.all in
# executeToolCallsParallel) and both call ctx.ui.confirm/select/input/
# editor/custom, the second call orphans the first's resolve callback.
# The first tool's Promise never settles → Promise.all stalls forever.
#
# A correct fix serializes interactive dialog calls. The right place is
# either the runner (extensions/runner.ts wrapping ctx.ui) or
# InteractiveMode itself (queue inside showExtension*). Both approaches
# are valid.
#
# Grading slices:
#   G1 (0.10) Memo/investigation artifact substance
#   G2 (0.10) Memo concept coverage (root cause language)
#   G3 (0.15) Code change in correct hotspot files
#   G4 (0.20) Structural: a serialization primitive (queue/mutex) added
#   G5 (0.25) Behavioral: a runnable harness proves dialogs serialize
#               (concurrent calls do NOT orphan first resolver)
#   G6 (0.10) Project tests pass / no regression in pre-existing tests
#   G7 (0.10) New test exercising parallel interactive serialization
# Total = 1.00
# P2P gates: file integrity & no-truncation. Failure → REWARD=0.
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
for p in /root/.bun/bin /root/.nvm/versions/node/*/bin /usr/local/share/npm/bin /opt/homebrew/bin ; do
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
# P2P gating: file integrity
# ============================================================
echo "=== P2P: file integrity ==="
for f in "$INTERACTIVE_TS" "$RUNNER_TS" "$AGENT_LOOP_TS"; do
  SIZE=$(wc -c < "$f" 2>/dev/null || echo 0)
  if [ "$SIZE" -lt 500 ]; then
    echo "REGRESSION: $f truncated ($SIZE bytes)"
    REWARD=0
    finish
  fi
done

# Compute diff stats
DIFF_LINES_HOTSPOT=0
DIFF_LINES_TOTAL=0
NEW_FILES=""
if [ -d "$REPO/.git" ]; then
  DIFF_LINES_HOTSPOT=$(cd "$REPO" && git diff HEAD -- \
    "packages/coding-agent/src/modes/interactive/interactive-mode.ts" \
    "packages/coding-agent/src/core/extensions/runner.ts" \
    "packages/agent/src/agent-loop.ts" \
    2>/dev/null | wc -l)
  DIFF_LINES_TOTAL=$(cd "$REPO" && git diff HEAD 2>/dev/null | wc -l)
  NEW_FILES=$(cd "$REPO" && git status --porcelain 2>/dev/null | grep -E '^\?\?' | awk '{print $2}')
fi
echo "Hotspot diff lines: $DIFF_LINES_HOTSPOT  Total diff lines: $DIFF_LINES_TOTAL"

# ============================================================
# Aggregate agent-produced text (memo + new files + diff additions)
# ============================================================
: > /tmp/memo_content.txt
: > /tmp/new_test_files.txt

if [ -d "$REPO/.git" ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    full="$REPO/$f"
    [ -f "$full" ] || continue
    case "$f" in
      *node_modules/*|*.git/*|*dist/*|*/README.md|*CHANGELOG*) continue ;;
    esac
    case "$f" in
      *.md|*.txt|*.MD)
        SIZE=$(wc -c < "$full" 2>/dev/null || echo 0)
        [ "$SIZE" -lt 300 ] && continue
        cat "$full" >> /tmp/memo_content.txt
        echo "" >> /tmp/memo_content.txt
        ;;
      *test*.ts|*test*.tsx|*.test.ts|*.spec.ts)
        echo "$f" >> /tmp/new_test_files.txt
        cat "$full" >> /tmp/memo_content.txt
        ;;
      *)
        cat "$full" >> /tmp/memo_content.txt
        ;;
    esac
  done < <(cd "$REPO" && git status --porcelain 2>/dev/null | grep -E '^\?\?' | awk '{print $2}')

  # Diff additions (existing-file edits)
  (cd "$REPO" && git diff HEAD 2>/dev/null) | grep "^+" | grep -v "^+++" | sed 's/^+//' >> /tmp/memo_content.txt
fi

MEMO_LEN=$(wc -c < /tmp/memo_content.txt 2>/dev/null || echo 0)
echo "Aggregated agent-produced text: $MEMO_LEN bytes"

# ============================================================
# G1 (0.10): Memo / artifact substance
# ============================================================
echo ""
echo "=== G1: Memo substance (max 0.10) ==="
G1=$(awk -v n="$MEMO_LEN" 'BEGIN{
  if (n>=10000) print 0.10;
  else if (n>=5000) print 0.07;
  else if (n>=2000) print 0.04;
  else if (n>=500)  print 0.02;
  else print 0;
}')
echo "G1=$G1"
add_reward "$G1"

# ============================================================
# G2 (0.10): Concept coverage of root cause
# Requires text mentioning parallel/Promise.all + serialize/queue
# + interactive/dialog + the showExtension* / editorContainer terms.
# ============================================================
echo ""
echo "=== G2: Concept coverage (max 0.10) ==="
G2=$(node -e '
const fs=require("fs");
let t="";try{t=fs.readFileSync("/tmp/memo_content.txt","utf8").toLowerCase();}catch(e){}
if(t.length<400){console.log(0);process.exit(0);}
const groups=[
  [/parallel/, /promise\.all/, /executetoolcallsparallel/],
  [/sequential|serial(ize|ised|ized)?|queue|mutex|enqueue/],
  [/interactive|dialog|extensionselector|extensioninput|extensioneditor|extensioncustom|ctx\.ui|ui\.confirm|ui\.select/],
  [/orphan|stall|deadlock|race|overwrit|clobber|clear\(\)/],
];
let hits=0;
for(const g of groups){ if(g.some(r=>r.test(t))) hits++; }
const score = (hits/groups.length)*0.10;
console.log(score.toFixed(4));
' 2>/dev/null)
[ -z "$G2" ] && G2=0
echo "G2=$G2"
add_reward "$G2"

# ============================================================
# G3 (0.15): Code change in correct hotspot files
# Reward distributed: any hotspot edit (0.05), runner.ts OR interactive-mode.ts
# (the two valid fix locations) (+0.10 if at least one).
# ============================================================
echo ""
echo "=== G3: Hotspot code change (max 0.15) ==="
G3=0
RUNNER_DIFF=0
INTERACTIVE_DIFF=0
AGENT_DIFF=0
if [ -d "$REPO/.git" ]; then
  RUNNER_DIFF=$(cd "$REPO" && git diff HEAD -- "packages/coding-agent/src/core/extensions/runner.ts" 2>/dev/null | wc -l)
  INTERACTIVE_DIFF=$(cd "$REPO" && git diff HEAD -- "packages/coding-agent/src/modes/interactive/interactive-mode.ts" 2>/dev/null | wc -l)
  AGENT_DIFF=$(cd "$REPO" && git diff HEAD -- "packages/agent/src/agent-loop.ts" 2>/dev/null | wc -l)
fi
echo "Diff lines  runner=$RUNNER_DIFF  interactive=$INTERACTIVE_DIFF  agentLoop=$AGENT_DIFF"

if [ "$RUNNER_DIFF" -ge 10 ] || [ "$INTERACTIVE_DIFF" -ge 10 ]; then
  G3=0.10
fi
# Bonus 0.05 if substantial fix (at least one of these has a real change)
if [ "$RUNNER_DIFF" -ge 30 ] || [ "$INTERACTIVE_DIFF" -ge 30 ]; then
  G3=$(awk -v g="$G3" 'BEGIN{ printf "%.4f", g+0.05 }')
fi

echo "G3=$G3"
add_reward "$G3"

# ============================================================
# G4 (0.20): Structural — a serialization primitive present in the diff
# Look in either runner.ts or interactive-mode.ts for an enqueue / mutex /
# promise-chain that serializes dialog calls.
# ============================================================
echo ""
echo "=== G4: Serialization primitive present (max 0.20) ==="
G4=0
PRIM_HITS=0
for f in "$INTERACTIVE_TS" "$RUNNER_TS"; do
  [ -f "$f" ] || continue
  # Look for queue field declaration (Promise<...> = Promise.resolve()) or chain pattern.
  if grep -qE "(dialogQueue|_uiDialogQueue|uiQueue|dialogTail|_dialogQueue)\s*[:=].*Promise" "$f" 2>/dev/null; then
    PRIM_HITS=$((PRIM_HITS+1))
  fi
  # Or an enqueue helper / .then(run, run) chain
  if grep -qE "(enqueueDialog|withSerializedDialogs|serializeDialog)" "$f" 2>/dev/null; then
    PRIM_HITS=$((PRIM_HITS+1))
  fi
done

# Confirm the queue is actually wired to dialog methods (not just declared)
WIRED=0
for f in "$INTERACTIVE_TS" "$RUNNER_TS"; do
  [ -f "$f" ] || continue
  if grep -qE "(dialogQueue|_uiDialogQueue|uiQueue)" "$f" 2>/dev/null && \
     grep -qE "(showExtensionSelector|showExtensionInput|showExtensionEditor|showExtensionCustom|ui\.select|ui\.confirm|ui\.input|ui\.editor)" "$f" 2>/dev/null; then
    WIRED=1
  fi
  if grep -qE "enqueueDialog" "$f" 2>/dev/null; then
    # Count enqueueDialog usages – needs to wrap multiple methods
    USES=$(grep -cE "enqueueDialog" "$f" 2>/dev/null)
    if [ "$USES" -ge 3 ]; then
      WIRED=1
    fi
  fi
done

if [ "$PRIM_HITS" -ge 1 ] && [ "$WIRED" -eq 1 ]; then
  G4=0.20
elif [ "$PRIM_HITS" -ge 1 ]; then
  G4=0.10
fi
echo "PRIM_HITS=$PRIM_HITS  WIRED=$WIRED  G4=$G4"
add_reward "$G4"

# ============================================================
# G5 (0.25): Behavioral harness — concurrent dialog calls do not orphan.
#
# Build a synthetic scenario: simulate the runner OR InteractiveMode
# serialization. We construct a fake ctx.ui where each method takes 1 ms
# and returns an answer; we call select() twice concurrently AND assert:
#   - both promises resolve
#   - they resolve in order (first started, first resolved)
#   - max concurrency observed = 1 (only one dialog "active" at a time)
#
# This requires either:
#   (a) the runner wrapping ctx.ui with serialization, or
#   (b) InteractiveMode's dialog queue to actually serialize.
#
# We test path (a) directly, since it's portable: reload runner.ts via
# tsx/node, instantiate the runner, set a probing UI context, and observe.
#
# If runner-level serialization isn't present, we fall back to a structural
# probe that re-confirms G4 evidence — but this gate only fires its full
# weight on observed runtime serialization.
# ============================================================
echo ""
echo "=== G5: Behavioral serialization harness (max 0.25) ==="
G5=0

cd "$REPO" || finish

# Try installation: prefer existing node_modules, otherwise we must skip.
HAS_DEPS=0
if [ -d "$REPO/node_modules" ] || [ -d "$REPO/packages/coding-agent/node_modules" ]; then
  HAS_DEPS=1
fi

# Make sure tsx/vitest available (look for vitest binary anywhere)
VITEST_BIN=""
for c in "$REPO/node_modules/.bin/vitest" "$REPO/packages/coding-agent/node_modules/.bin/vitest"; do
  [ -x "$c" ] && VITEST_BIN="$c" && break
done

# Build a vitest-style standalone test that validates serialization at the
# runner.ts wrapping layer. We write the test into the new path and run it
# through the project's vitest if available.
HARNESS_PATH="$REPO/packages/coding-agent/test/__verifier_serialization.test.ts"
mkdir -p "$(dirname "$HARNESS_PATH")"

cat > "$HARNESS_PATH" <<'EOF'
import { describe, it, expect } from "vitest";
import { ExtensionRunner } from "../src/core/extensions/runner.js";

// Minimal ExtensionUIContext that records concurrency.
function makeProbeUI() {
  let active = 0;
  let maxActive = 0;
  const order: string[] = [];
  const ui = {
    select: async (title: string, _options: string[], _opts?: any) => {
      active++;
      maxActive = Math.max(maxActive, active);
      order.push("start:" + title);
      await new Promise((r) => setTimeout(r, 15));
      order.push("end:" + title);
      active--;
      return _options[0];
    },
    confirm: async (title: string) => {
      active++;
      maxActive = Math.max(maxActive, active);
      order.push("start:" + title);
      await new Promise((r) => setTimeout(r, 15));
      order.push("end:" + title);
      active--;
      return true;
    },
    input: async (title: string) => {
      active++;
      maxActive = Math.max(maxActive, active);
      order.push("start:" + title);
      await new Promise((r) => setTimeout(r, 15));
      order.push("end:" + title);
      active--;
      return "ok";
    },
    editor: async (title: string) => {
      active++;
      maxActive = Math.max(maxActive, active);
      order.push("start:" + title);
      await new Promise((r) => setTimeout(r, 15));
      order.push("end:" + title);
      active--;
      return "ok";
    },
    custom: async () => {
      active++;
      maxActive = Math.max(maxActive, active);
      await new Promise((r) => setTimeout(r, 15));
      active--;
      return undefined;
    },
  } as any;
  return { ui, get max() { return maxActive; }, order };
}

describe("verifier serialization", () => {
  it("runner serializes concurrent dialog calls (max=1, in order)", async () => {
    const runner: any = new (ExtensionRunner as any)();
    const probe = makeProbeUI();
    runner.setUIContext(probe.ui);

    // Build a context the same way runner does for an extension call.
    let ctx: any;
    try {
      ctx = (runner as any).buildExtensionUIContext
        ? (runner as any).buildExtensionUIContext()
        : (runner as any).getExtensionUIContext
          ? (runner as any).getExtensionUIContext()
          : null;
    } catch {
      ctx = null;
    }
    // Fallback: use whatever ctx the runner exposes via internal accessor
    if (!ctx) {
      // walk the runner to find a method that returns an ExtensionUIContext
      const proto = Object.getPrototypeOf(runner);
      for (const k of Object.getOwnPropertyNames(proto)) {
        try {
          const v = (runner as any)[k];
          if (typeof v === "function" && v.length === 0) {
            const r = v.call(runner);
            if (r && typeof r === "object" && typeof r.select === "function") {
              ctx = r;
              break;
            }
          }
        } catch {}
      }
    }
    if (!ctx) {
      // Last-ditch: maybe runner exposes a context property
      const cands = ["ui", "context", "uiContextWrapped", "extensionContext"];
      for (const k of cands) {
        const v: any = (runner as any)[k];
        if (v && typeof v.select === "function") { ctx = v; break; }
      }
    }
    expect(ctx, "could not locate runner ExtensionUIContext").toBeTruthy();

    // Fire two concurrent select calls.
    const p1 = ctx.select("A", ["x"]);
    const p2 = ctx.select("B", ["y"]);
    const results = await Promise.all([p1, p2]);
    expect(results).toEqual(["x", "y"]);
    // Critical assertion: dialogs were serialized.
    expect(probe.max).toBe(1);
    // And in start order.
    expect(probe.order[0]).toBe("start:A");
    expect(probe.order[1]).toBe("end:A");
    expect(probe.order[2]).toBe("start:B");
    expect(probe.order[3]).toBe("end:B");
  });
});
EOF

VITEST_PASS=0
VITEST_TRIED=0
if [ -n "$VITEST_BIN" ] && [ "$HAS_DEPS" -eq 1 ]; then
  VITEST_TRIED=1
  echo "Running verifier serialization test via vitest..."
  cd "$REPO/packages/coding-agent" || cd "$REPO"
  OUT=$(timeout 90 "$VITEST_BIN" run test/__verifier_serialization.test.ts --reporter=verbose 2>&1)
  echo "$OUT" | tail -80
  if echo "$OUT" | grep -qE "(1 passed|Tests +1 passed)"; then
    VITEST_PASS=1
  fi
  cd "$REPO"
fi

# Cleanup harness regardless
rm -f "$HARNESS_PATH"

if [ "$VITEST_PASS" -eq 1 ]; then
  G5=0.25
else
  # Fallback structural probe: if runner.ts exposes a wrapped UI that
  # delegates select/confirm/input/editor/custom through enqueueDialog or
  # a queue chain — and the wrapping is wired in setUIContext or in the
  # ctx getter — award partial credit (the fix is structurally correct
  # but we can't run the project tests).
  WRAP_HITS=0
  if [ -f "$RUNNER_TS" ]; then
    grep -qE "(enqueueDialog|withSerializedDialogs)" "$RUNNER_TS" && WRAP_HITS=$((WRAP_HITS+1))
    # Count distinct dialog methods routed through the queue
    METHODS=0
    for m in select confirm input editor custom; do
      if grep -qE "${m}.*enqueueDialog|enqueueDialog.*${m}|tail.*${m}" "$RUNNER_TS" 2>/dev/null; then
        METHODS=$((METHODS+1))
      fi
    done
    if [ "$METHODS" -ge 4 ]; then WRAP_HITS=$((WRAP_HITS+1)); fi
  fi
  if [ -f "$INTERACTIVE_TS" ]; then
    if grep -qE "dialogQueue|_uiDialogQueue|enqueueDialog" "$INTERACTIVE_TS"; then
      # count showExtension* methods that route through queue
      METHODS=0
      for m in showExtensionSelector showExtensionInput showExtensionEditor showExtensionCustom; do
        # crude proximity check: method body uses queue identifier
        if awk "/private (async )?${m}/,/^	}$/" "$INTERACTIVE_TS" 2>/dev/null | grep -qE "(dialogQueue|_uiDialogQueue|enqueueDialog)"; then
          METHODS=$((METHODS+1))
        fi
      done
      if [ "$METHODS" -ge 3 ]; then WRAP_HITS=$((WRAP_HITS+2)); fi
      if [ "$METHODS" -ge 1 ] && [ "$METHODS" -lt 3 ]; then WRAP_HITS=$((WRAP_HITS+1)); fi
    fi
  fi

  if [ "$WRAP_HITS" -ge 3 ]; then
    G5=0.15
  elif [ "$WRAP_HITS" -ge 2 ]; then
    G5=0.10
  elif [ "$WRAP_HITS" -ge 1 ]; then
    G5=0.05
  else
    G5=0
  fi
fi
echo "VITEST_TRIED=$VITEST_TRIED VITEST_PASS=$VITEST_PASS G5=$G5"
add_reward "$G5"

# ============================================================
# G6 (0.10): Pre-existing tests still pass (P2P-style, but weighted as
# a positive signal). On no-op repo we don't run anything → 0.
# Only run if hotspot diff exists AND vitest is available, otherwise 0.
# ============================================================
echo ""
echo "=== G6: Pre-existing tests pass (max 0.10) ==="
G6=0
if [ "$DIFF_LINES_HOTSPOT" -gt 0 ] && [ -n "$VITEST_BIN" ] && [ "$HAS_DEPS" -eq 1 ]; then
  cd "$REPO/packages/coding-agent" || cd "$REPO"
  # Run a bounded test subset (existing harness tests) to confirm no
  # regression. We avoid the new test files the agent added — those are
  # graded separately in G7.
  EXISTING_TESTS=$(find test -type f -name '*.test.ts' 2>/dev/null | head -5)
  if [ -n "$EXISTING_TESTS" ]; then
    PASS_COUNT=0
    FAIL_COUNT=0
    for tf in $EXISTING_TESTS; do
      # skip files added by the agent
      if [ -d "$REPO/.git" ]; then
        STATUS=$(cd "$REPO" && git status --porcelain "packages/coding-agent/$tf" 2>/dev/null | head -c 2)
        if [ "$STATUS" = "??" ]; then
          continue
        fi
      fi
      OUT=$(timeout 60 "$VITEST_BIN" run "$tf" --reporter=basic 2>&1)
      if echo "$OUT" | grep -qE "Tests +[0-9]+ passed"; then
        P=$(echo "$OUT" | grep -oE "Tests +[0-9]+ passed" | head -1 | grep -oE "[0-9]+")
        PASS_COUNT=$((PASS_COUNT + ${P:-0}))
      fi
      if echo "$OUT" | grep -qE "Tests +[0-9]+ failed"; then
        F=$(echo "$OUT" | grep -oE "Tests +[0-9]+ failed" | head -1 | grep -oE "[0-9]+")
        FAIL_COUNT=$((FAIL_COUNT + ${F:-0}))
      fi
    done
    echo "Existing tests: PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
    if [ "$PASS_COUNT" -ge 3 ] && [ "$FAIL_COUNT" -eq 0 ]; then
      G6=0.10
    elif [ "$PASS_COUNT" -ge 1 ] && [ "$FAIL_COUNT" -eq 0 ]; then
      G6=0.05
    fi
  fi
  cd "$REPO"
fi
echo "G6=$G6"
add_reward "$G6"

# ============================================================
# G7 (0.10): Agent added a regression test exercising parallel
# interactive serialization (concept: parallel + dialog/confirm/select +
# expects no stall / max=1 / both resolve).
# ============================================================
echo ""
echo "=== G7: Agent-added regression test (max 0.10) ==="
G7=0
NEW_TESTS=$(grep -E '\.(test|spec)\.ts' /tmp/new_test_files.txt 2>/dev/null)
TEST_HIT=0
TEST_RUN_PASS=0
if [ -n "$NEW_TESTS" ]; then
  for tf in $NEW_TESTS; do
    full="$REPO/$tf"
    [ -f "$full" ] || continue
    LCONTENT=$(tr '[:upper:]' '[:lower:]' < "$full")
    has_parallel=0; has_dialog=0; has_concurrent_assert=0
    echo "$LCONTENT" | grep -qE "parallel|promise\.all|concurrent" && has_parallel=1
    echo "$LCONTENT" | grep -qE "confirm|select|extensionselector|ctx\.ui|showextension" && has_dialog=1
    echo "$LCONTENT" | grep -qE "tohavelength\(2\)|both.*resolve|maxconcurrent|expect\(.*\)\.tobe\(1\)|deadlock|stall|orphan" && has_concurrent_assert=1
    if [ $((has_parallel + has_dialog + has_concurrent_assert)) -ge 2 ]; then
      TEST_HIT=1
    fi
    # Try to run it
    if [ -n "$VITEST_BIN" ] && [ "$HAS_DEPS" -eq 1 ]; then
      pkg=$(echo "$tf" | grep -oE "^packages/[^/]+")
      [ -z "$pkg" ] && pkg="packages/coding-agent"
      relpath=$(echo "$tf" | sed "s#^$pkg/##")
      cd "$REPO/$pkg" 2>/dev/null || cd "$REPO"
      OUT=$(timeout 60 "$VITEST_BIN" run "$relpath" --reporter=basic 2>&1)
      if echo "$OUT" | grep -qE "Tests +[1-9][0-9]* passed" && ! echo "$OUT" | grep -qE "Tests +[1-9][0-9]* failed"; then
        TEST_RUN_PASS=1
      fi
      cd "$REPO"
    fi
  done
fi

if [ "$TEST_HIT" -eq 1 ] && [ "$TEST_RUN_PASS" -eq 1 ]; then
  G7=0.10
elif [ "$TEST_HIT" -eq 1 ]; then
  G7=0.05
fi
echo "TEST_HIT=$TEST_HIT TEST_RUN_PASS=$TEST_RUN_PASS G7=$G7"
add_reward "$G7"

# ============================================================
# Final
# ============================================================
echo ""
echo "=== Final reward: $REWARD ==="
echo "$REWARD" > /logs/verifier/reward.txt